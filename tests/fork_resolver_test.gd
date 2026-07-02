extends GdUnitTestSuite

# ForkResolver — the pure fork path-picking logic extracted from GameLoop /
# ForkScreen. All deterministic: the random draw (r), score/coins value, and item
# ownership are passed in, so no RNG or autoload is involved here.


# Builds an is_owned Callable backed by a fixed owned-items list.
func _owns(items: Array) -> Callable:
	return func(id: String) -> bool: return id in items


# ── weighted_pick ────────────────────────────────────────────────────────────


# r lands in the cumulative bracket of its index. weights [1,2,1] → [1,3,4):
# r 0 → idx0, r 1-2 → idx1, r 3 → idx2.
func test_weighted_pick_brackets() -> void:
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 0)).is_equal(0)
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 1)).is_equal(1)
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 2)).is_equal(1)
	assert_int(ForkResolver.weighted_pick([1, 2, 1], 3)).is_equal(2)


func test_weighted_pick_single_and_empty() -> void:
	assert_int(ForkResolver.weighted_pick([5], 0)).is_equal(0)
	assert_int(ForkResolver.weighted_pick([5], 4)).is_equal(0)
	assert_int(ForkResolver.weighted_pick([], 0)).is_equal(0)


# Zero-weight paths are never picked — r falls through them to the next bracket.
func test_weighted_pick_skips_zero_weights() -> void:
	assert_int(ForkResolver.weighted_pick([0, 0, 3], 0)).is_equal(2)
	assert_int(ForkResolver.weighted_pick([0, 0, 3], 2)).is_equal(2)


# ── conditional_path: score / coins thresholds ──────────────────────────────


func test_conditional_highest_met_threshold_wins() -> void:
	var paths := [{"threshold": 0}, {"threshold": 100}, {"threshold": 200}]
	assert_int(ForkResolver.conditional_path(paths, "score", 0, 150, _owns([]))).is_equal(1)
	assert_int(ForkResolver.conditional_path(paths, "score", 0, 250, _owns([]))).is_equal(2)
	assert_int(ForkResolver.conditional_path(paths, "score", 0, 50, _owns([]))).is_equal(0)


# The coins metric runs the same threshold path (value is supplied by the caller).
func test_conditional_coins_metric_uses_thresholds() -> void:
	var paths := [{"threshold": 0}, {"threshold": 50}]
	assert_int(ForkResolver.conditional_path(paths, "coins", 0, 75, _owns([]))).is_equal(1)
	assert_int(ForkResolver.conditional_path(paths, "coins", 0, 25, _owns([]))).is_equal(0)


# No path's threshold met → the (clamped) default path.
func test_conditional_no_match_uses_default() -> void:
	var paths := [{"threshold": 100}, {"threshold": 200}]
	assert_int(ForkResolver.conditional_path(paths, "score", 1, 50, _owns([]))).is_equal(1)
	# default_path out of range is clamped into bounds.
	assert_int(ForkResolver.conditional_path(paths, "score", 99, 50, _owns([]))).is_equal(1)


# ── conditional_path: item ownership ────────────────────────────────────────


func test_conditional_item_picks_first_owned() -> void:
	var paths := [{"required_item": ""}, {"required_item": "key"}, {"required_item": "gem"}]
	assert_int(ForkResolver.conditional_path(paths, "item", 0, 0, _owns(["gem"]))).is_equal(2)
	assert_int(ForkResolver.conditional_path(paths, "item", 0, 0, _owns(["key", "gem"]))).is_equal(
		1
	)
	assert_int(ForkResolver.conditional_path(paths, "item", 0, 0, _owns([]))).is_equal(0)  # default


func test_conditional_empty_paths() -> void:
	assert_int(ForkResolver.conditional_path([], "score", 0, 100, _owns([]))).is_equal(0)


# ── path_affordable (Sacrifice gating) ──────────────────────────────────────


func test_affordable_free_path() -> void:
	assert_bool(ForkResolver.path_affordable(0, "", 0, _owns([]))).is_true()


func test_affordable_coin_cost() -> void:
	assert_bool(ForkResolver.path_affordable(50, "", 100, _owns([]))).is_true()
	assert_bool(ForkResolver.path_affordable(50, "", 50, _owns([]))).is_true()  # exact
	assert_bool(ForkResolver.path_affordable(50, "", 30, _owns([]))).is_false()  # short


func test_affordable_required_item() -> void:
	assert_bool(ForkResolver.path_affordable(0, "key", 0, _owns(["key"]))).is_true()
	assert_bool(ForkResolver.path_affordable(0, "key", 0, _owns([]))).is_false()


# Both gates must pass.
func test_affordable_coins_and_item() -> void:
	assert_bool(ForkResolver.path_affordable(50, "key", 100, _owns(["key"]))).is_true()
	assert_bool(ForkResolver.path_affordable(50, "key", 100, _owns([]))).is_false()  # has coins, no item
	assert_bool(ForkResolver.path_affordable(50, "key", 30, _owns(["key"]))).is_false()  # has item, no coins
